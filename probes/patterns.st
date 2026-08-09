struct Point {
    x: int32;
    y: int32;
}

union Shape {
    point(Point), rect(int32, int32)
}

fn classify(value: int32) -> int32 {
    match (value) {
        0 => 10,
        1 => 20,
        _ => 30,
    }
}

fn exact(values: list[int32]) -> int32 {
    match (values) {
        [] => 0,
        [only] => only,
        [first, second] => first + second,
        [head, ..tail] => head,
    }
}

fn area(shape: Shape) -> int32 {
    match (shape) {
        Shape::point(Point { x, y }) => x + y,
        Shape::rect(width, height) => width * height,
    }
}

fn main() -> void {
    let _ = classify(1);
    let _ = exact([1, 2]);
    let _ = area(Shape::point(Point { x: 3, y: 4 }));
}
