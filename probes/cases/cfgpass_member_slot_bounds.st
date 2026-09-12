const builtin = import("builtin");
const greeting: str = "hello";
fn main() -> void {
    let s = greeting;
    builtin.print(s);
}
