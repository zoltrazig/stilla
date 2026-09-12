const builtin = import("builtin");
using builtin.Option;
fn main() -> int32 {
    let a: Option[int32] = Option::Some(42);
    match (a) { Option::Some(v) => v, Option::None => 0 }
}
