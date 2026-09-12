const math = import("math");
fn get_pi() -> float32 { math.pi }
fn main() -> float32 {
    let x = math.sqrt(4.0);
    x + get_pi()
}
