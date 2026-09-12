const math = import("math");
fn apply(f: fn(float32) -> float32, x: float32) -> float32 { f(x) }
fn main() -> float32 { apply(math.sqrt, 4.0) }
