const builtin = import("builtin");
struct Token { id: int32; drop(t) { let x = t.id; } }
fn make(id: int32) -> Token { Token { id: id } }
fn f(x: int32) -> int32 {
    let _ = make(builtin.hash(x));
    7
}
