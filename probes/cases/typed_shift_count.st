const builtin = import("builtin");
fn main(p: int32, s: int32) -> void {
    let r = p << s;
    builtin.print(builtin.str(r));
}
