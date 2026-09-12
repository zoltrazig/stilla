const string = import("string");
using string.upper as up;
fn shout(text: str) -> str { up(text) }
fn main() -> void { let _ = shout("hi"); }
