fn i32_cmp(a: int32, b: int32) -> tuple[bool, bool, bool, bool, bool, bool] { (a == b, a != b, a < b, a <= b, a > b, a >= b) }
fn u32_cmp(a: uint32, b: uint32) -> tuple[bool, bool, bool, bool, bool, bool] { (a == b, a != b, a < b, a <= b, a > b, a >= b) }
fn i64_cmp(a: int64, b: int64) -> tuple[bool, bool, bool, bool, bool, bool] { (a == b, a != b, a < b, a <= b, a > b, a >= b) }
fn u64_cmp(a: uint64, b: uint64) -> tuple[bool, bool, bool, bool, bool, bool] { (a == b, a != b, a < b, a <= b, a > b, a >= b) }
fn f32_cmp(a: float32, b: float32) -> tuple[bool, bool, bool, bool, bool, bool] { (a == b, a != b, a < b, a <= b, a > b, a >= b) }
fn f64_cmp(a: float64, b: float64) -> tuple[bool, bool, bool, bool, bool, bool] { (a == b, a != b, a < b, a <= b, a > b, a >= b) }
fn byte_cmp(a: byte, b: byte) -> tuple[bool, bool] { (a == b, a != b) }
fn bool_cmp(a: bool, b: bool) -> tuple[bool, bool] { (a == b, a != b) }
fn str_cmp(a: str, b: str) -> tuple[bool, bool] { (a == b, a != b) }

fn i32_branch(a: int32, b: int32) -> int32 { if (a == b) { 0 } else if (a < b) { 1 } else if (a <= b) { 2 } else { 3 } }
fn u32_branch(a: uint32, b: uint32) -> int32 { if (a != b) { 0 } else if (a < b) { 1 } else if (a <= b) { 2 } else { 3 } }
fn i64_branch(a: int64, b: int64) -> int32 { if (a == b) { 0 } else if (a < b) { 1 } else if (a <= b) { 2 } else { 3 } }
fn u64_branch(a: uint64, b: uint64) -> int32 { if (a != b) { 0 } else if (a < b) { 1 } else if (a <= b) { 2 } else { 3 } }
fn f32_branch(a: float32, b: float32) -> int32 { if (a == b) { 0 } else if (a < b) { 1 } else if (a <= b) { 2 } else { 3 } }
fn f64_branch(a: float64, b: float64) -> int32 { if (a != b) { 0 } else if (a < b) { 1 } else if (a <= b) { 2 } else { 3 } }

fn main() -> void {}
