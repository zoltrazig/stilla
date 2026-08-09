fn both(a: bool, b: bool) -> bool {
    (a and b) or !a
}

fn main() -> void {
    let _ = both(true, false);
}
