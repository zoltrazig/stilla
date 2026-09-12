// select — scalar if-expressions of every if-convertible type plus a
// unique aggregate that must stay branchy. Exercises if-conversion's
// scalar-Copy-only rule and the phi it replaces.

struct Point {
    x: int32;
    y: int32;
}

fn pick_int(flag: bool, a: int32, b: int32) -> int32 { if (flag) { a } else { b } }
fn pick_uint(flag: bool, a: uint32, b: uint32) -> uint32 { if (flag) { a } else { b } }
fn pick_byte(flag: bool, a: byte, b: byte) -> byte { if (flag) { a } else { b } }
fn pick_float(flag: bool, a: float64, b: float64) -> float64 { if (flag) { a } else { b } }
fn pick_bool(flag: bool, a: bool, b: bool) -> bool { if (flag) { a } else { b } }

fn pick_point(flag: bool, a: Point, b: Point) -> Point {
    if (flag) { a } else { b }
}

fn main() -> void {
    let _ = pick_int(true, 1, 2);
    let _ = pick_uint(false, 1, 2);
    let _ = pick_byte(true, 1 as byte, 2 as byte);
    let _ = pick_float(false, 1.5, 2.5);
    let _ = pick_bool(true, true, false);
    let _ = pick_point(true, Point { x: 1, y: 2 }, Point { x: 3, y: 4 });
}
