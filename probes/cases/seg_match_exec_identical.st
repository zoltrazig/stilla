const builtin = import("builtin");
union Value { number(int32), empty }
fn pick(v: int32) -> int32 {
    match (Value::number(v)) { Value::number(n) => n * 2, Value::empty => 0 }
}
fn main() -> void { builtin.print(builtin.str(pick(21))); }
