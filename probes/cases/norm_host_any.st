const builtin = import("builtin");
fn wrap(a: int64) -> any { a }
fn main() -> void {
    let v: int64 = 9007199254740993;
    let a = wrap(v);
    let w = (move a) as int64;
    builtin.print(builtin.str(1));
}
