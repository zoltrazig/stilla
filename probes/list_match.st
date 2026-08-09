fn first(values: list[int32]) -> int32 {
    match (values) {
        [head, ..tail] => head,
        [] => -1,
    }
}

fn consume(move values: list[str]) -> str {
    match (move values) {
        [head, ..tail] => {
            drop tail;
            move head
        },
        [] => "empty",
    }
}

fn main() -> void {
    let _ = first([1, 2, 3]);
    let values = ["first", "second"];
    let result = consume(move values);
    drop result;
}
