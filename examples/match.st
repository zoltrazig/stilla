// match — union dispatch, switch terminators, and join phis (Core §11, §13).
//
// `area` matches a `Shape` union value; the lowerer emits a `read_tag`
// plus a `switch` terminator over the variant discriminants, with one
// block per arm and a join phi for the match result.

const builtin = import("builtin");

union Shape {
    circle(int32), rect(int32, int32)
}

fn area(s: Shape) -> int32 {
    match (s) {
        Shape::circle(r) => r * r * 3,
        Shape::rect(w, h) => w * h,
    }
}

fn main() -> void {
    let s = Shape::rect(3, 4);
    builtin.print(builtin.str(area(s)));
}
