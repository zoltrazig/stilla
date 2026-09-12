fn iadd(a: int32, b: int32) -> int32 { a + b }
fn uadd(a: uint32, b: uint32) -> uint32 { a + b }
fn fadd(a: float32, b: float32) -> float32 { a + b }
fn imul(a: int32, b: int32) -> int32 { a * b }
fn umul(a: uint32, b: uint32) -> uint32 { a * b }
fn fdiv(a: float32, b: float32) -> float32 { a / b }
fn imod(a: int32, b: int32) -> int32 { a % b }
fn umod(a: uint32, b: uint32) -> uint32 { a % b }
fn ineg(a: int32) -> int32 { -a }
fn uneg(a: uint32) -> uint32 { -a }
fn fneg(a: float32) -> float32 { -a }
fn lnot(a: bool) -> bool { !a }
fn cat(a: str, b: str) -> str { a + b }
fn main() -> void {
    iadd(1, 2); uadd(1 as uint32, 2 as uint32); fadd(1.0, 2.0);
    imul(1, 2); umul(1 as uint32, 2 as uint32); fdiv(1.0, 2.0);
    imod(1, 2); umod(1 as uint32, 2 as uint32);
    ineg(1); uneg(1 as uint32); fneg(1.0); lnot(true); cat("a", "b");
}
