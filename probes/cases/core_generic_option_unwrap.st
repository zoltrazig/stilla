const builtin = import("builtin");
struct Option[T] {
    val: T;
}
fn unwrap[T](o: Option[T]) -> T {
    match (o) {
        Option[T] { val } => val
    }
}
fn main() -> void {
    let o: Option[int32] = Option[int32] { val: 42 };
    let v = unwrap[int32](o);
    builtin.print(builtin.str(v));
}
