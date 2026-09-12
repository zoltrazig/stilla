const builtin = import("builtin");
const L = import("list");
fn main() -> void {
    let n = 42;
    let s = builtin.str(n);
    let b = builtin.box[int32](n);
    let v = builtin.unbox[int32](move b);
    builtin.print(s);
    builtin.print(s);
    let xs = L.range[int32](0, 5);
    let len = L.len[int32](xs);
    builtin.assert(v == n and len == 5, "ok");
}
