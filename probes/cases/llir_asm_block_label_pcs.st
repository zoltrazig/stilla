const builtin = import("builtin");
union Result { Ok(int32), Err(int32) }
fn choose(t: bool, a: int32, b: int32) -> int32 { if (t) { a } else { b } }
fn tag(r: Result) -> int32 {
    match (r) { Result::Ok(n) => n, Result::Err(n) => n }
}
fn main() -> void {
    let v = choose(true, 1, 2);
    let k = tag(Result::Ok(9));
    builtin.print(builtin.str(v + k));
}
