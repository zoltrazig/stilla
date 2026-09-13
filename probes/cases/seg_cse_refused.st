// CSE sharing refused shapes: a `div` pair (may trap → not total, so not
// an island member / not duplicable), and two α-equivalent `mul`s that
// sit in separate source-`let` initializers (each its own full
// expression, so never operands of one node).
fn div_pair(x: int32, y: int32) -> int32 { (x / y) + (x / y) }
fn cross_fe(x: int32, y: int32) -> int32 {
    let a = x * y;
    let b = x * y;
    a + b
}
fn main() -> void { }
