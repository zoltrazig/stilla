struct Token {
    value: int32;
    drop(token) {}
}

fn copy_roundtrip(value: int32) -> int32 {
    let dynamic: any = value;
    dynamic as int32
}

fn move_roundtrip(move token: Token) -> Token {
    let dynamic: any = move token;
    (move dynamic) as Token
}

fn classify(value: any) -> int32 {
    match (value) {
        int32 n => n,
        str text => 1,
        _ => 0,
    }
}

fn main() -> void {
    let _ = copy_roundtrip(42);
    let token = Token { value: 42 };
    let restored = move_roundtrip(move token);
    drop restored;
    let dynamic: any = "probe";
    let _ = classify(move dynamic);
}
