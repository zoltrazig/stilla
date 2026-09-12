const builtin = import("builtin");
using builtin.Option;
fn s() -> str { builtin.str(Option::Some(1)) }
fn main() -> void {}
