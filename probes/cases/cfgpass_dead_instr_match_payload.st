const builtin = import("builtin");
using builtin.Option;
fn is_some(o: Option[int32]) -> bool {
    match (o) {
        Option::Some(v) => true,
        Option::None => false,
    }
}
fn main() -> void {}
