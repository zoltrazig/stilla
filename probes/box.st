const builtin = import("builtin");

struct Token {
    value: int32;
    drop(token) {}
}

fn main() -> void {
    let copy_box = builtin.box::[int32](42);
    let _ = builtin.unbox::[int32](copy_box);
    let _ = builtin.unbox::[int32](move copy_box);

    let unique_box = builtin.box::[Token](Token { value: 7 });
    let token = builtin.unbox::[Token](move unique_box);
    drop token;
}
