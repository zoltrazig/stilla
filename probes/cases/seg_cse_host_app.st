// Two α-equivalent host reads as operands of one `add`: the declaration
// decides whether they are observably effectful (write) or a
// non-observable `Q` read — neither is `isDuplicable`, so CSE must not
// merge them.
const sensor = import("sensor");
fn f(x: int32) -> int32 { sensor.read(x) + sensor.read(x) }
fn main() -> void { }
