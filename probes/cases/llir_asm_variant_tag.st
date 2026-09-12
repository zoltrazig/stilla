union Shape { circle(int32), rect(int32, int32) }
fn area(s: Shape) -> int32 {
    match (s) {
        Shape::rect(w, h) => w * h,
        Shape::circle(r) => r,
    }
}
fn main() -> void {}
