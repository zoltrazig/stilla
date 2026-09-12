const lists = import("list");
fn take(f: fn(str) -> void) -> void { f("hi") }
fn main() -> void { take(lists.builtin.print) }
