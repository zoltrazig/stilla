fn beq(a: byte, b: byte) -> bool { a == b }
fn bne(a: byte, b: byte) -> bool { a != b }
fn blt(a: byte, b: byte) -> bool { a < b }
fn bge(a: byte, b: byte) -> bool { a >= b }
fn main() -> void {
    let a: byte = 1 as byte; let b: byte = 2 as byte;
    beq(a, b); bne(a, b); blt(a, b); bge(a, b);
}
