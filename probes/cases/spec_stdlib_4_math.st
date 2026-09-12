const math = import("math");
const builtin = import("builtin");
fn main() -> float32 {
    let radius = 2.0;
    let area = math.pi * math.pow(radius, 2.0);
    let diagonal = math.sqrt(3.0 * 3.0 + 4.0 * 4.0);
    area + diagonal
}
