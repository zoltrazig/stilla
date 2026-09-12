const builtin = import("builtin");
const lib = import("lib");
fn main() -> void {
    let s = lib.math.sqrt;
    let r = s(4);
    builtin.print(builtin.str(r));
}
