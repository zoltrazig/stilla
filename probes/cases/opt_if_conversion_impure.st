const builtin = import("builtin");
fn f(c: bool, a: int32, b: int32) -> int32 {
    if (c) { builtin.print(builtin.str(a)); a } else { b }
}
fn main() -> void { let _ = f(true, 1, 2); }
