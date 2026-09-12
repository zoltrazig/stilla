const builtin = import("builtin");
struct Token { id: int32; drop(t) { builtin.print(builtin.str(t.id)); } }
fn make(id: int32) -> Token { Token { id: id } }
fn take(move t: Token) -> int32 { t.id }
fn main() -> void {
    let first = take(make(1));
    make(2);
    builtin.print(builtin.str(first));
    make(3);
}
