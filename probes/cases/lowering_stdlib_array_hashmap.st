const array = import("array");
const hashmap = import("hashmap");
const builtin = import("builtin");
using builtin.Option;
fn main() -> void {
    let a = array.make(4, 0);
    let x = array.get::[int32](a, 2);
    let n = array.len::[int32](a);
    let a = array.set(move a, 2, 42);
    let b = array.clone::[int32](a);
    let m = hashmap.empty::[str, int32]();
    let m = hashmap.insert(move m, "a", 1);
    let m = hashmap.insert(move m, "b", 2);
    match (hashmap.get::[str, int32](m, "a")) {
        Option::Some(value) => builtin.print(builtin.str(value)),
        Option::None => builtin.print("missing")
    };
    let (m, removed) = hashmap.remove::[str, int32](move m, "a");
    let c = hashmap.clone::[str, int32](m);
}
