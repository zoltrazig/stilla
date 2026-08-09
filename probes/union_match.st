union Value {
    number(int32), empty
}

struct Token {
    value: int32;
    drop(token) {}
}

union Owned {
    token(Token), empty
}

fn read(value: Value) -> int32 {
    match (value) {
        Value::number(n) => n,
        Value::empty => 0,
    }
}

fn take(move value: Owned) -> int32 {
    match (move value) {
        Owned::token(token) => {
            let result = token.value;
            drop token;
            result
        },
        Owned::empty => 0,
    }
}

fn inspect(borrow value: Owned) -> int32 {
    match (value) {
        Owned::token(token) => token.value,
        Owned::empty => 0,
    }
}

fn main() -> void {
    let _ = read(Value::number(42));
    let owned = Owned::token(Token { value: 42 });
    let _ = inspect(owned);
    let _ = take(move owned);
}
