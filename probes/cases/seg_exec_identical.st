const builtin = import("builtin");
fn idf(x: int32) -> int32 { x }
fn calc(v: int32) -> int32 {
    let a: int32 = (fn(x: int32) -> int32 { x + 0 })(idf(v));
    let b = if (a > 0) { a * 1 } else { 10 / 2 };
    b + (2 + 3)
}
fn main() -> void {
    builtin.print(builtin.str(calc(7)));
    builtin.print(builtin.str(calc(0)));
}
