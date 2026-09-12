const builtin = import("builtin");
union Value { number(int32), empty }
fn f(x: int32) -> int32 {
    match (Value::number(x)) {
        Value::number(n) => n,
        Value::empty => { builtin.print("no"); 0 },
    }
}
fn main() -> void { }
