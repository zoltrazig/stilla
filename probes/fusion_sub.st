// `a - b * c` for every numeric representation: the LLIR fusion pass
// selects the register-form `msub` (there is no multiply-accumulate
// immediate form), reading the product operand from its slot.
//
// No printing: the consumers/SEG differentials compare stdout verbatim,
// so the probe asserts instead.

const builtin = import("builtin");

fn msub_i32(a: int32, b: int32, c: int32) -> int32 { a - b * c }
fn msub_u32(a: uint32, b: uint32, c: uint32) -> uint32 { a - b * c }
fn msub_i64(a: int64, b: int64, c: int64) -> int64 { a - b * c }
fn msub_u64(a: uint64, b: uint64, c: uint64) -> uint64 { a - b * c }
fn msub_f32(a: float32, b: float32, c: float32) -> float32 { a - b * c }
fn msub_f64(a: float64, b: float64, c: float64) -> float64 { a - b * c }

fn main() -> void {
    builtin.assert(msub_i32(20, 3, 4) == 8, "int32 msub");
    builtin.assert(msub_u32(20, 3, 4) == 8, "uint32 msub");
    builtin.assert(msub_i64(20, 3, 4) == 8, "int64 msub");
    builtin.assert(msub_u64(20, 3, 4) == 8, "uint64 msub");
    builtin.assert(msub_f32(10.0, 2.0, 3.0) == 4.0, "float32 msub");
    builtin.assert(msub_f64(10.0, 2.0, 3.0) == 4.0, "float64 msub");
}
