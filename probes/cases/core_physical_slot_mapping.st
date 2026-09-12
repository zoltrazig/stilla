const builtin = import("builtin");
fn pick(a: int32, b: int32) -> int32 {
    if (a < b) { a } else { b }
}
fn dead(a: int32) -> int32 { 7 }
fn main() -> void {
    let x = pick(1, 2);
    builtin.print(builtin.str(x));
}
