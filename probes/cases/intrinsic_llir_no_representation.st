const builtin = import("builtin");
const math = import("math");
const lists = import("list");
fn main() -> void {
    let x = math.sqrt(4.0);
    let n = lists.len([1, 2]);
    builtin.print("ok");
}
