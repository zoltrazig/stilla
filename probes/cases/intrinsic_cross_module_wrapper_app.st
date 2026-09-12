const math = import("math");
const lib = import("lib");
fn base() -> float32 {
    let f = math.sqrt;
    f(9.0)
}
fn main() -> float32 { base() }
