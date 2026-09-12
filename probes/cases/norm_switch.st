union Shape { Circle(int32), Rect(int32, int32) }
fn area(s: Shape) -> int32 {
    match (s) { Shape::Circle(r) => r, Shape::Rect(w, h) => w * h }
}
fn main() -> int32 { area(Shape::Circle(3)) }
