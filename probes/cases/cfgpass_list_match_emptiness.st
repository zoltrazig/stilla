fn count_list(xs: list[int32]) -> int32 {
    match (xs) {
        [] => 0,
        [_, ..tail] => 1 + count_list(tail),
    }
}
fn main() -> void {}
