const builtin = import("builtin");
const array = import("array");
using builtin.Option;
struct File {
    fd: int32;
    path: str;
    drop(f) {
        builtin.print(f.path);
    }
}
union Result {
    Ok(int32),
    Err(str),
}
fn main() -> void {
    let f = File{ fd: 3, path: "x" };
    let r = Result::Ok(1);
    builtin.print(builtin.str(1));
}
