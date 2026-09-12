fn b_i(a: byte) -> int32 { a as int32 }
fn b_u(a: byte) -> uint32 { a as uint32 }
fn b_f(a: byte) -> float32 { a as float32 }
fn b_d(a: byte) -> float64 { a as float64 }
fn i_b(a: int32) -> byte { a as byte }
fn i_u(a: int32) -> uint32 { a as uint32 }
fn i_f(a: int32) -> float32 { a as float32 }
fn i_d(a: int32) -> float64 { a as float64 }
fn u_b(a: uint32) -> byte { a as byte }
fn u_i(a: uint32) -> int32 { a as int32 }
fn u_f(a: uint32) -> float32 { a as float32 }
fn u_d(a: uint32) -> float64 { a as float64 }
fn f_b(a: float32) -> byte { a as byte }
fn f_i(a: float32) -> int32 { a as int32 }
fn f_u(a: float32) -> uint32 { a as uint32 }
fn f_d(a: float32) -> float64 { a as float64 }
fn d_b(a: float64) -> byte { a as byte }
fn d_i(a: float64) -> int32 { a as int32 }
fn d_u(a: float64) -> uint32 { a as uint32 }
fn d_f(a: float64) -> float32 { a as float32 }
fn main() -> void {
    let a: byte = 1 as byte; let b: int32 = 1; let c: uint32 = 1 as uint32;
    let d: float32 = 1.0; let e: float64 = 1.0;
    b_i(a); b_u(a); b_f(a); b_d(a); i_b(b); i_u(b); i_f(b); i_d(b);
    u_b(c); u_i(c); u_f(c); u_d(c); f_b(d); f_i(d); f_u(d); f_d(d);
    d_b(e); d_i(e); d_u(e); d_f(e);
}
