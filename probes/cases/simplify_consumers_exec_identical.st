const builtin = import("builtin");
fn pure(x: int32) -> int32 { x * 2 }
fn calc(v: int32) -> int32 {
    let unused: int32 = pure(v);
    pure(3) + builtin.hash(builtin.str(v))
}
fn main() -> void {
    builtin.print(builtin.str(calc(7)));
    builtin.print(builtin.str(calc(0)));
}
