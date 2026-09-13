// CSE sharing refused for a Unique operand: the two α-equivalent `Token`
// constructors are Unique and consumed by the aggregate binding, so
// neither is an island member and `isDuplicable == false`.
struct Token {
    value: int32;
    drop(token) {}
}

struct Two {
    a: Token;
    b: Token;
}

fn f(v: int32) -> int32 {
    let two = Two { a: Token { value: v }, b: Token { value: v } };
    two.a.value + two.b.value
}

fn main() -> void { }
