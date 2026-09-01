fn byte_value() -> byte { 255 as byte }
fn i32_value() -> int32 { 42 }
fn u32_value() -> uint32 { 4294967295 as uint32 }
fn i64_value() -> int64 { 9223372036854775807 }
fn u64_zero() -> uint64 { 0 }
fn u64_low() -> uint64 { 65535 }
fn u64_high_lane() -> uint64 { 4294967296 }
fn u64_all_lanes() -> uint64 { 81985529216486895 }
fn u64_max() -> uint64 { 18446744073709551615 }
fn f32_value() -> float32 { 1.5 }
fn f64_value() -> float64 { 1.5 }
fn bool_value() -> bool { true }
fn str_value() -> str { "probe" }

fn main() -> void {}
