const builtin = import("builtin");
const lists = import("list");
fn describe(a: any) -> int32 {
    match (a) {
        int32 n => n,
        str s => lists.len(["x"]),
        _ => -1
    }
}
fn main() -> void {}
