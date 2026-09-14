// A Unique operand the parent transfers: `take(make(x))`. `make` prints,
// so the operand is observably effectful and not floatable — selective
// ANF materializes it (`let B = make(x) in take(%B)`), and because the
// call consumes the binder exactly as it consumed the anonymous
// temporary, nothing is destroyed at the synthesized let's scope end
// (docs/effects.md §11.2, docs/hir.md §5.7).
const builtin = import("builtin");
struct Token { id: int32; drop(t) { let x = t.id; } }
fn make(id: int32) -> Token {
    builtin.print("make");
    Token { id: id }
}
fn take(move t: Token) -> int32 { t.id }
fn f(x: int32) -> int32 { take(make(x)) }