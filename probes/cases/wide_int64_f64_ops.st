fn iadd(a: int64, b: int64) -> int64 { a + b }
fn usub(a: uint64, b: uint64) -> uint64 { a - b }
fn imul(a: int64, b: int64) -> int64 { a * b }
fn idiv(a: int64, b: int64) -> int64 { a / b }
fn udiv(a: uint64, b: uint64) -> uint64 { a / b }
fn irem(a: int64, b: int64) -> int64 { a % b }
fn urem(a: uint64, b: uint64) -> uint64 { a % b }
fn ineg(a: int64) -> int64 { -a }
fn fadd(a: float64, b: float64) -> float64 { a + b }
fn fsub(a: float64, b: float64) -> float64 { a - b }
fn fmul(a: float64, b: float64) -> float64 { a * b }
fn fdiv(a: float64, b: float64) -> float64 { a / b }
fn frem(a: float64, b: float64) -> float64 { a % b }
fn fneg(a: float64) -> float64 { -a }
fn ishl(a: int64, b: int64) -> int64 { a << b }
fn ushr(a: uint64, b: uint64) -> uint64 { a >> b }
fn ishr(a: int64, b: int64) -> int64 { a >> b }
fn iand(a: int64, b: int64) -> int64 { a & b }
fn uor(a: uint64, b: uint64) -> uint64 { a | b }
fn uxor(a: uint64, b: uint64) -> uint64 { a ^ b }
fn ilt(a: int64, b: int64) -> bool { a < b }
fn ult(a: uint64, b: uint64) -> bool { a < b }
fn ule(a: uint64, b: uint64) -> bool { a <= b }
fn ige(a: int64, b: int64) -> bool { a >= b }
fn ugt(a: uint64, b: uint64) -> bool { a > b }
fn igt(a: int64, b: int64) -> bool { a > b }
fn ieq(a: int64, b: int64) -> bool { a == b }
fn une(a: uint64, b: uint64) -> bool { a != b }
fn flt(a: float64, b: float64) -> bool { a < b }
fn fle(a: float64, b: float64) -> bool { a <= b }
fn fge(a: float64, b: float64) -> bool { a >= b }
fn fgt(a: float64, b: float64) -> bool { a > b }
fn feq(a: float64, b: float64) -> bool { a == b }
fn fne(a: float64, b: float64) -> bool { a != b }
fn main() -> void {
    let a: int64 = 1; let b: int64 = 2;
    let c: uint64 = 1; let d: uint64 = 2;
    let e: float64 = 1.0; let f: float64 = 2.0;
    iadd(a, b); usub(c, d); imul(a, b); idiv(a, b); udiv(c, d); irem(a, b); urem(c, d);
    ineg(a); fadd(e, f); fsub(e, f); fmul(e, f); fdiv(e, f); frem(e, f); fneg(e);
    ishl(a, b); ushr(c, d); ishr(a, b); iand(a, b); uor(c, d); uxor(c, d);
    ilt(a, b); ult(c, d); ule(c, d); ige(a, b); ugt(c, d); igt(a, b); ieq(a, b); une(c, d);
    flt(e, f); fle(e, f); fge(e, f); fgt(e, f); feq(e, f); fne(e, f);
}
