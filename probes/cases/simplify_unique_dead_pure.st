struct Token { id: int32; drop(t) { let x = t.id; } }
fn make(id: int32) -> Token { Token { id: id } }
fn f(id: int32) -> int32 {
    let unused = make(id);
    0
}
