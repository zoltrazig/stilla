const builtin = import("builtin");
fn s(b: byte, i: int32, u: uint32, i2: int64, u2: uint64, f: float32, f2: float64, bo: bool, st: str) -> str {
    builtin.str(b) + builtin.str(i) + builtin.str(u) + builtin.str(i2) + builtin.str(u2) + builtin.str(f) + builtin.str(f2) + builtin.str(bo) + builtin.str(st)
}
fn h(b: byte, i: int32, u: uint32, i2: int64, u2: uint64, f: float32, f2: float64, bo: bool, st: str) -> int32 {
    builtin.hash(b) + builtin.hash(i) + builtin.hash(u) + builtin.hash(i2) + builtin.hash(u2) + builtin.hash(f) + builtin.hash(f2) + builtin.hash(bo) + builtin.hash(st)
}
fn main() -> void {}
