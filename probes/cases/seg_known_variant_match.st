union Value { number(int32), empty }
union Flag { on, off }
union Two { pair(int32, int32), none }
fn single(x: int32) -> int32 {
    match (Value::number(x)) { Value::number(n) => n + 1, Value::empty => 0 }
}
fn nullary() -> int32 { match (Flag::off) { Flag::on => 1, Flag::off => 2 } }
fn multi(x: int32, y: int32) -> int32 {
    match (Two::pair(x, y)) { Two::pair(a, b) => a - b, Two::none => 0 }
}
fn main() -> void { }
