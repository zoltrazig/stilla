// any — dynamic payloads with statically checked recovery.
//
// A type-test match safely narrows an `any`. An explicit `as` recovers a
// known payload type and traps at runtime if the stored type differs.

const builtin = import("builtin");

fn classify(value: any) -> int32 {
    match (value) {
        int32 n => n,
        str text => 100,
        bool flag => if (flag) { 1 } else { 0 },
        _ => -1,
    }
}

fn main() -> void {
    let number: any = 42;
    builtin.assert(classify(move number) == 42, "int32 type pattern");

    let text: any = "stilla";
    builtin.assert(classify(move text) == 100, "str type pattern");

    let dynamic: any = 41;
    let restored = dynamic as int32;
    builtin.assert(restored + 1 == 42, "explicit recovery");
}
