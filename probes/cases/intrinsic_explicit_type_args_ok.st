const array = import("array");
const hashmap = import("hashmap");
fn al(borrow a: array.Array[int32]) -> int32 { array.len::[int32](a) }
fn h(move m: hashmap.HashMap[int32, int32], k: int32) -> hashmap.HashMap[int32, int32] {
    hashmap.insert(move m, k, 7)
}
fn main() -> void {}
