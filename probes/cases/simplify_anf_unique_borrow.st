struct Token { id: int32; drop(t) { let x = t.id; } }
fn make(id: int32) -> Token { Token { id: id } }
fn show(borrow t: Token) -> int32 { t.id }
fn f(x: int32) -> int32 { show(make(x)) }
