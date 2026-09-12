struct Token { id: int32; drop(t) { let x = t.id; } }
fn f(id: int32) -> int32 {
    let unused = Token { id: id };
    7
}
