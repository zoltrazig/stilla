fn eqi(a: int32, b: int32) -> bool { a == b }
fn neu(a: uint32, b: uint32) -> bool { a != b }
fn ltf(a: float32, b: float32) -> bool { a < b }
fn geu(a: uint32, b: uint32) -> bool { a >= b }
fn eqb(a: byte, b: byte) -> bool { a == b }
fn eqbl(a: bool, b: bool) -> bool { a == b }
fn eqs(a: str, b: str) -> bool { a == b }
fn f2i(a: float32) -> int32 { a as int32 }
fn i2f(a: int32) -> float32 { a as float32 }
fn i2b(a: int32) -> byte { a as byte }
fn b2i(a: byte) -> int32 { a as int32 }
fn i2u(a: int32) -> uint32 { a as uint32 }
fn u2i(a: uint32) -> int32 { a as int32 }
fn main() -> void {
    eqi(1, 2); neu(1 as uint32, 2 as uint32); ltf(1.0, 2.0); geu(1 as uint32, 2 as uint32);
    eqb(1 as byte, 2 as byte); eqbl(true, false); eqs("a", "b");
    f2i(1.0); i2f(1); i2b(1); b2i(1 as byte); i2u(1); u2i(1 as uint32);
}
