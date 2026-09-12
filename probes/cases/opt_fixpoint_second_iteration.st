struct Token { id: int32; }
fn make(id: int32) -> Token {
    Token { id: id }
}
fn show(borrow t: Token) -> int32 {
    t.id
}
fn consume(move t: Token) -> void {
    drop t;
}
fn main() -> void {
    let a = make(7);
    let n = show(a);
    consume(move a);
}
