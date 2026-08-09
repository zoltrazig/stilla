struct Token {
    value: int32;

    drop(token) {}
}

fn consume(move token: Token) -> void {
    drop token;
}

fn main() -> void {
    let token = Token { value: 42 };
    consume(move token);
}
