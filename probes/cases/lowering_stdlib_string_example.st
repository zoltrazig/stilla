const string = import("string");
fn main() -> void {
    let s = string.from_utf8([104 as byte, 101 as byte, 108 as byte, 108 as byte, 111 as byte]);
    let parts = string.split(s, "l");
    let joined = string.join(parts, "-");
    let bytes = string.to_utf8(s);
    let cps = string.to_codepoints(s);
    let upper = string.upper(s);
}
