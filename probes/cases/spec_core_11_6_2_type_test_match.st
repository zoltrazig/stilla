const builtin = import("builtin");
fn main() -> void {
    let a: any = 42;
    match (a) {
        int32 n => builtin.print(builtin.str(n)),
        str s => builtin.print(s),
        _ => builtin.print("other")
    };
}
