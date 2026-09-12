const hashmap = import("hashmap");
fn h(move m: hashmap.HashMap[int32, any], k: int32, v: any) -> hashmap.HashMap[int32, any] {
    hashmap.insert(move m, k, v)
}
fn main() -> void {}
