// structs — product types, field access, tuples, and destructuring.

const builtin = import("builtin");

type Offset = tuple[int32, int32];

struct Point {
    x: int32;
    y: int32;
}

fn main() -> void {
    let origin = Point { x: 0, y: 0 };
    let offset: Offset = (3, 4);
    let (dx, dy) = offset;
    let moved = Point { x: origin.x + dx, y: origin.y + dy };
    builtin.assert(moved.x == 3 and moved.y == 4, "struct fields");

    let pair = (moved.x, moved.y);
    let (x, y) = pair;
    builtin.assert(x * x + y * y == 25, "tuple destructuring");
}
