const array = import("array");
struct Inner { arr: array.Array[int32]; }
struct Outer { inner: Inner; }
fn main() -> void {
    let o = Outer { inner: Inner { arr: array.make(10, 0) } };
}
