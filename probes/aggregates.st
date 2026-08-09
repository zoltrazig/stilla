struct Point {
    x: int32;
    y: int32;
}

struct Token {
    value: int32;
    drop(token) {}
}

fn project(point: Point, offset: tuple[int32, int32]) -> int32 {
    let (dx, dy) = offset;
    point.x + dx + point.y + dy
}

fn unpack_point(point: Point) -> int32 {
    let Point { x: x, y: y } = point;
    x + y
}

fn unpack_pair(move pair: tuple[Token, Token]) -> void {
    let (left, right) = move pair;
    drop left;
    drop right;
}

fn main() -> void {
    let _ = project(Point { x: 1, y: 2 }, (3, 4));
    let _ = unpack_point(Point { x: 1, y: 2 });
    let pair = (Token { value: 1 }, Token { value: 2 });
    unpack_pair(move pair);
}
