struct Point { x: int32; y: int32; }
union Shape { point(Point), empty }
fn f() -> int32 {
    match (Shape::point(Point { x: 1, y: 2 })) {
        Shape::point(Point { x, y }) => x + y,
        Shape::empty => 0,
    }
}
fn main() -> void { }
