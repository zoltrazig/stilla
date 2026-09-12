const builtin = import("builtin");
fn main(p: int32, q: int32) -> void {
    let r = p + q;
    builtin.print(builtin.str(r));
}
