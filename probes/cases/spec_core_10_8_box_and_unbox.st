const builtin = import("builtin");
struct Token { id: int32; }
fn main() -> int32 {
    let t = builtin.box(Token { id: 7 });
    let t2 = builtin.unbox(move t);
    t2.id
}
