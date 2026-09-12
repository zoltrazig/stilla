const hostmod = import("hostmod");
struct Token { id: int32; drop(t) { hostmod.log(t.id); } }
fn f(id: int32) -> int32 {
    let unused = Token { id: id };
    7
}
