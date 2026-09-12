const builtin = import("builtin");
const lists = import("list");
union Result { Ok(int32), Err(str) }
fn describe(r: Result) -> str {
    match (r) {
        Result::Ok(v) => builtin.str(v),
        Result::Err(e) => e
    }
}
fn main() -> void {}
