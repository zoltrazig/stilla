const builtin = import("builtin");
fn h() -> int32 { builtin.hash([1, 2]) }
fn main() -> void {}
