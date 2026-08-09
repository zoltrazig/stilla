struct Token {
    value: int32;
    drop(token) {}
}

struct Pair {
    left: Token;
    right: Token;
}

fn consume(move token: Token) -> void {
    drop token;
}

fn make(value: int32) -> Token {
    Token { value: value }
}

fn conditional(flag: bool) -> void {
    let token = make(1);
    if (flag) {
        consume(move token);
    }
}

fn main() -> void {
    let pair = Pair {
        left: make(2),
        right: make(3),
    };
    make(4);
}
