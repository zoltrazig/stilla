// ownership — affine values, a user drop hook, borrow/move/drop (Core §10).
//
// `Token` defines a user `drop` hook that prints the id, so it is an
// affine type: it is borrowed (`show`), explicitly dropped, and moved
// (`consume`). Destruction is explicit in the IR: scope-end drops, a
// hook call on `drop`, and the borrow/move boundary at the call sites.

const builtin = import("builtin");

struct Token {
    id: int32;

    drop(t) {
        builtin.print(builtin.str(t.id));
    }
}

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
    builtin.print(builtin.str(n));
    consume(move a);
}
