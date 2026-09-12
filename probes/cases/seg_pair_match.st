union Pair { both(int32, int32), none }
fn f(x: int32, y: int32) -> int32 {
    match (Pair::both(x, y)) { Pair::both(a, b) => a - b, Pair::none => 0 }
}
fn main() -> void { }
