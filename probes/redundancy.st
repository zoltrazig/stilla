// redundancy — the same pure computation in several arms and after a join.
// Exercises common-subexpression elimination, copy propagation, and partial
// redundancy elimination: the duplicated expression is a candidate at the
// join, and the repeated field loads are block-local CSE candidates.

struct Box {
    value: int32;
    flag: bool;
}

fn side(flag: bool, b: Box) -> int32 {
    if (flag) {
        b.value + b.value
    } else {
        b.value + b.value
    }
}

fn joined(flag: bool, x: int32, y: int32) -> int32 {
    let a = if (flag) { x * y } else { x * y };
    a + x * y
}

fn rotated(x: int32, y: int32) -> int32 {
    let z = x + y;
    let w = x + y;
    (z * w) + (z * w)
}

fn main() -> void {
    let b = Box { value: 3, flag: true };
    let _ = side(true, b);
    let _ = side(false, b);
    let _ = joined(true, 2, 5);
    let _ = joined(false, 2, 5);
    let _ = rotated(3, 4);
}
