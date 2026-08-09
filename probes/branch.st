fn choose(flag: bool, a: int32, b: int32) -> int32 {
    if (flag) { a } else { b }
}

fn main() -> void {
    let _ = choose(true, 1, 2);
}
