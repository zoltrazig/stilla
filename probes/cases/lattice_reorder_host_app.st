// Reads of two sibling host domains as operands of one `add`: `read` reads
// host(2), `peek` reads host(3) (see `lattice_reorder_host_sensor.st`). The
// flat provider keeps them conflicting (no swap); the `example_hierarchy`
// lattice proves the pair disjoint and the reorder rule puts the operands
// in canonical order — `read` before `peek`. `main` calls `f` so the
// whole-chain AIR carries the calls.
const sensor = import("sensor");
fn f(x: int32) -> int32 { sensor.peek(x) + sensor.read(x) }
fn main() -> void { let _: int32 = f(1); }