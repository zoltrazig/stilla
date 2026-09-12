const hashmap = import("hashmap");
fn h(move m: hashmap.HashMap[int32, int32]) -> hashmap.HashMap[int32, int32] {
    hashmap.insert(move m, 1, 2)
}
fn main() -> void {}
