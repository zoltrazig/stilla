const builtin = import("builtin");
fn pick_str(c: bool, a: str, b: str) -> str {
    if (c) { a } else { b }
}
fn main() -> void {
    let s = pick_str(true, "x", "y");
    builtin.print(s);
}
