union Value { number(int32), empty }
fn wild(x: int32) -> int32 {
    match (Value::number(x)) { Value::number(_) => 7, Value::empty => 0 }
}
fn catchall(x: int32) -> int32 { match (Value::number(x)) { v => 7 } }
fn main() -> void { }
