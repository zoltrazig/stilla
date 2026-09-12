struct Token { id: int32; drop(t) { let x = t.id; } }
fn make(id: int32) -> Token { Token { id: id } }
fn take(move t: Token) -> int32 { t.id }
fn f(x: int32) -> int32 { take(make(x)) }
