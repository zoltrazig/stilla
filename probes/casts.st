fn from_byte(x: byte) -> tuple[int32, uint32, float32, float64] { (x as int32, x as uint32, x as float32, x as float64) }
fn from_i32(x: int32) -> tuple[byte, uint32, float32, float64] { (x as byte, x as uint32, x as float32, x as float64) }
fn from_u32(x: uint32) -> tuple[byte, int32, float32, float64] { (x as byte, x as int32, x as float32, x as float64) }
fn from_f32(x: float32) -> tuple[byte, int32, uint32, float64] { (x as byte, x as int32, x as uint32, x as float64) }
fn from_f64(x: float64) -> tuple[byte, int32, uint32, float32] { (x as byte, x as int32, x as uint32, x as float32) }

fn main() -> void {}
