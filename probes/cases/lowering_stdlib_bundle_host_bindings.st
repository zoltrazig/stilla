const builtin = import("builtin");
const lists = import("list");
const m = import("math");
const s = import("string");
fn main() -> int32 {
    lists.len(lists.range(0, 10)) + m.sqrt(2.0) as int32 + s.len("hi")
}
