const builtin = import("builtin");
struct Token { id: int32; }
fn main() -> void {
    let b = builtin.box::[int32](42);
    let v = builtin.unbox::[int32](move b);
    builtin.assert(v == 42, "unbox");
    let t = builtin.box::[Token](Token { id: 7 });
    let t2 = builtin.unbox::[Token](move t);
    builtin.assert(t2.id == 7, "round-trip");
}
