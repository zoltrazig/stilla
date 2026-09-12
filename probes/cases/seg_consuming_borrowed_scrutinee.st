struct Token { value: int32; drop(token) {} }
union Owned { token(Token), empty }
fn take(move value: Owned) -> int32 {
    match (move value) { Owned::token(t) => t.value, Owned::empty => 0 }
}
fn inspect(borrow value: Owned) -> int32 {
    match (value) { Owned::token(t) => t.value, Owned::empty => 0 }
}
fn main() -> void { }
